---
name: scikit-learn
import: sklearn
version: 1.5.x
category: Machine Learning
tags: ml, classifier, regressor, clustering, preprocessing
bundled: true
---

# scikit-learn

**Classical machine-learning toolkit.** Full iOS arm64 build with all the core estimators, transformers, cross-validation, and metrics.

## Classification

```python
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.metrics import classification_report, confusion_matrix

X, y = make_classification(n_samples=500, n_features=10, random_state=0)
Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.25, random_state=0)

clf = RandomForestClassifier(n_estimators=100, random_state=0).fit(Xtr, ytr)
print(clf.score(Xte, yte))
print(classification_report(yte, clf.predict(Xte)))
```

## Regression

```python
from sklearn.linear_model import LinearRegression, Ridge, Lasso
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.metrics import mean_squared_error, r2_score

# Linear models
lm = Ridge(alpha=1.0).fit(Xtr, ytr)
print(r2_score(yte, lm.predict(Xte)))

# Non-linear
gbr = GradientBoostingRegressor(n_estimators=200, max_depth=3).fit(Xtr, ytr)
```

## Clustering

```python
from sklearn.cluster import KMeans, DBSCAN, AgglomerativeClustering
from sklearn.datasets import make_blobs

X, _ = make_blobs(n_samples=300, centers=4, cluster_std=0.6, random_state=0)

km = KMeans(n_clusters=4, n_init=10).fit(X)
db = DBSCAN(eps=0.5, min_samples=5).fit(X)
hc = AgglomerativeClustering(n_clusters=4).fit(X)
```

## Pipelines + grid search

```python
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC
from sklearn.model_selection import GridSearchCV

pipe = Pipeline([
    ("scaler", StandardScaler()),
    ("svc",    SVC()),
])
grid = {"svc__C": [0.1, 1, 10], "svc__kernel": ["rbf", "linear"]}
gs = GridSearchCV(pipe, grid, cv=5).fit(Xtr, ytr)
print(gs.best_params_, gs.best_score_)
```

## Preprocessing

```python
from sklearn.preprocessing import (
    StandardScaler, MinMaxScaler, RobustScaler,
    OneHotEncoder, OrdinalEncoder, LabelEncoder,
    PolynomialFeatures, PowerTransformer,
)

from sklearn.decomposition import PCA, NMF
from sklearn.feature_selection import SelectKBest, f_classif, VarianceThreshold
```

## Dimensionality reduction & manifold

```python
from sklearn.decomposition import PCA
from sklearn.manifold import TSNE, Isomap

Xpca = PCA(n_components=2).fit_transform(X)
Xtsne = TSNE(n_components=2, perplexity=30, init="pca").fit_transform(X)
```

## Common models at a glance

| Task | Class |
|---|---|
| Linear classifier | `LogisticRegression`, `LinearSVC`, `SGDClassifier` |
| Tree ensembles | `RandomForestClassifier`, `GradientBoostingClassifier`, `ExtraTreesClassifier` |
| Kernel classifier | `SVC(kernel="rbf")` |
| Linear regressor | `LinearRegression`, `Ridge`, `Lasso`, `ElasticNet` |
| Non-linear regressor | `GradientBoostingRegressor`, `RandomForestRegressor`, `KNeighborsRegressor` |
| Clustering | `KMeans`, `DBSCAN`, `AgglomerativeClustering`, `GaussianMixture` |
| Dim reduction | `PCA`, `TruncatedSVD`, `NMF`, `TSNE`, `Isomap` |

## Metrics cheat-sheet

```python
from sklearn.metrics import (
    accuracy_score, f1_score, precision_score, recall_score, roc_auc_score,
    confusion_matrix, classification_report,
    mean_squared_error, mean_absolute_error, r2_score,
    silhouette_score, davies_bouldin_score,
)
```

## iOS notes

- HistGradientBoosting, CatBoost, XGBoost are NOT in the standard sklearn — use `GradientBoostingRegressor` or install xgboost separately (if a pure-Python wheel is published).
- Models pickle-save to Documents normally: `import joblib; joblib.dump(clf, "model.joblib")`.
- Parallel fits (`n_jobs=-1`) work but respect the iOS task-energy limits; don't go crazy on an iPhone.
